﻿using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using Text = TMPro.TMP_Text;
using UnityEngine.SceneManagement;
using DG.Tweening;

public class UIHooks : MonoBehaviour
{
    [SerializeField] Text healthText = default;
    [SerializeField] Image healthBar = default;
    [SerializeField] Image healthBarEffect = default;
    [SerializeField] Image fadeImage;
    public void SetHealth(int current, int total)
    {
        healthText.text = $"{current}/{total}";
        healthBar.fillAmount = current / (float)total;
        healthBarEffect.fillAmount = current / (float)total;
    }

    public void ReloadScene()
    {
        fadeImage.DOFade(1, 3).OnComplete(() => SceneManager.LoadSceneAsync(SceneManager.GetActiveScene().name));
    }
}
